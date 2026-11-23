import CobaltKit
import SwiftUI

// A twitch stream in the screen pane (apple/CONTRACT-PANE.md section 5; APP-API-CONTRACT 70). The player is the hero, the
// live chat is the shelf, laid out per room:
// - the pane beside the twitch tab (Duo held wide, iPad / Mac column): the chat moves to the tab, the right-hand panel
//   (`TwitchScreen`, `Pane.twitchChatBeside`), and the pane keeps the player and its buttons;
// - the pane on the Duo's top screen (held tall or half folded): the stream fills that whole screen, its buttons float over
//   the black band under the picture, and the chat is the twitch tab on the bottom screen (a chat button opens it);
// - spanned wide (iPad, Mac): the player over its buttons on the left, the chat the full height of the right half;
// - spanned over two screens: the player on one, the buttons over the chat filling the other.
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
            title: title, subtitle: subtitle, actions: actions,
            wideStyle: fillsScreen ? .heroOnly : .columns, fillsShelf: shape != .tall
        ) {
            hero
        } controls: {
            controls
        } body: {
            clipNote
        } shelf: {
            if !chatElsewhere {
                PaneCard(Copy.Twitch.chat) {
                    TwitchChatCard(model: model, delay: chatDelay, fills: shape != .tall)
                }
            }
        }
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

    // MARK: where things go

    /// The pane is one whole screen of a Duo held tall or half folded (the hinge across it): the stream takes all of it.
    private var fillsScreen: Bool {
        guard shape == .wide, pane.state == .screen, case .twoScreens(axis: .horizontal, hinge: _) = pane.placement else { return false }
        return true
    }

    /// The twitch tab beside the pane shows this stream's chat.
    private var chatInTab: Bool { pane.twitchChatBeside == login }

    /// The pane draws no chat: the tab beside it has it, or the stream fills the screen.
    private var chatElsewhere: Bool { chatInTab || fillsScreen }

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
        case .wide where fillsScreen:
            ZStack(alignment: .bottom) {
                Color.black
                playerOrTV(compact: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                overlayControls
            }
        case .wide, .split:
            ZStack {
                Color.black
                playerOrTV(compact: false)
            }
        }
    }

    /// The buttons over the bottom of a stream filling the screen: the big buttons as icons, the chat (on the twitch tab)
    /// when it is not up already, open on twitch, and stop.
    private var overlayControls: some View {
        VStack(spacing: 8) {
            clipNote
            HStack(spacing: 10) {
                ForEach(overlayActions) { PaneIconButton(action: $0) }
            }
        }
        .padding(.bottom, 14)
        .padding(.horizontal, 12)
    }

    private var overlayActions: [PaneAction] {
        var out = gridActions
        if !chatInTab {
            out.append(PaneAction(Copy.Twitch.showChat, systemImage: Symbol.Twitch.chat) {
                pane.provided(TwitchTabChat.self)?.browsing = false
                model.selectedTab = .twitch
            })
        }
        return out + actions
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

    private var chatDelay: TimeInterval { TwitchChatCard.tvDelay }
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

/// The chat as the shelf's card: a fixed height in a column that scrolls, or the rest of the room (`fills`). Also the
/// twitch tab's chat beside the pane (`TwitchScreen`).
struct TwitchChatCard: View {
    let model: AppModel
    let delay: TimeInterval
    var fills = false

    /// Video-only AirPlay runs the TV behind the phone: chat waits to match (70.5).
    static var tvDelay: TimeInterval {
        #if os(iOS)
        TwitchTV.shared.activeChatDelay
        #else
        0
        #endif
    }

    @Environment(\.paneShape) private var shape
    /// "add to a set" from the chat: a standard sheet over the pane, so the stream page stays mounted (and playing) under it.
    /// (A push inside the pane's `NavigationStack` would cover the pane's own header, which is the root page's overlay, and the
    /// stack has no back button; opening `.emoteAddToSet` would replace the stream.)
    @State private var addingToSet: SevenTvAddToSetModel?

    var body: some View {
        TwitchChatPane(model: model, delay: delay, showsLabel: false) { emote in
            guard let hit = emote.asHit else { return }
            SevenTvEmoteHits.remember(hit)
            addingToSet = model.sevenTv.addToSetPicker(emote: hit)
        }
        .frame(height: fills ? nil : height)
        .frame(maxHeight: fills ? .infinity : nil)
        .clipShape(.rect(cornerRadius: 14))
        .sheet(item: $addingToSet) { picker in
            SevenTvAddToSetSheet(picker: picker)
        }
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
