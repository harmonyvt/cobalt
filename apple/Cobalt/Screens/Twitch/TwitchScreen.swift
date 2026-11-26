import CobaltKit
import SwiftUI

// The twitch tab (APP-API-CONTRACT 70): a list of channels (search, your channel, who you follow that is live, recent).
// A channel opens in the screen pane (`TwitchStreamPage`: the player in the hero, chat on the shelf), which keeps
// playing in the bar when it is closed and while you switch tabs.
//
// While the pane plays a stream on screen BESIDE this tab (the Duo's other screen, the iPad / Mac column), this tab is the
// right-hand panel of the watch: it shows the stream's live chat at full height, with a "channels" button back to the list
// (and "show chat" back again). The pane then leaves the chat out (`Pane.twitchChatBeside`).

struct TwitchScreen: View {
    let model: AppModel
    let tier: Tier

    @Environment(\.lifecycle) private var lifecycle
    @Environment(Pane.self) private var pane
    /// Held here, handed to the pane weakly while this tab is up.
    @State private var tabChat = TwitchTabChat()

    private var store: TwitchStore { model.twitch }

    /// The channel whose chat this tab shows beside the pane (its display name once known).
    private var besideName: String? {
        guard let login = pane.twitchChatBeside else { return nil }
        return (store.channel == login ? store.channelInfo?.displayName : nil) ?? login
    }

    var body: some View {
        Group {
            if pane.twitchChatBeside != nil {
                TwitchBesideChat(model: model)
            } else {
                TwitchChannelList(model: model, besideStream: pane.streamBesideTab) { tabChat.browsing = false }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CobaltColor.bg)
        .navigationTitle(besideName ?? Copy.Twitch.title)
        // the chat beside a stream: the channel's name is the title and "channels" sits in the bar, so the lines get the
        // whole height under it
        .toolbar {
            if besideName != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { tabChat.browsing = true } label: {
                        Label(Copy.Twitch.channels, systemImage: Symbol.Twitch.channels)
                    }
                    .accessibilityIdentifier("twitch.channels")
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await store.load()
            if model.sevenTv.status == nil { await model.sevenTv.load() }
        }
        // back from studio (a reconnect) or from the background: a session that could not chat is asked again
        .onChange(of: lifecycle.phase) { _, phase in
            if phase == .active { Task { await store.load() } }
        }
        .onAppear { pane.provide(tabChat) }
        .onDisappear {
            if pane.provided(TwitchTabChat.self) === tabChat { pane.withdraw(TwitchTabChat.self) }
        }
        // a new stream opens with its chat up
        .onChange(of: pane.streamBesideTab) { _, login in if login != nil { tabChat.browsing = false } }
    }
}

/// The twitch tab is up (handed to the pane while it is): whether it shows the channel list instead of the chat.
@MainActor
@Observable
final class TwitchTabChat {
    var browsing = false
}

extension Pane {
    /// The stream on screen beside the tab (a Duo's other screen, the iPad / Mac column), not spanned, not a sheet.
    var streamBesideTab: String? {
        guard state == .screen, tabSize != nil, case .stream(let login)? = item else { return nil }
        return login
    }

    /// The stream whose chat the twitch tab beside the pane shows: the tab is up and not on its channel list.
    var twitchChatBeside: String? {
        guard let login = streamBesideTab, let tab = provided(TwitchTabChat.self), !tab.browsing else { return nil }
        return login
    }
}

// MARK: - the chat beside the pane

private struct TwitchBesideChat: View {
    let model: AppModel

    var body: some View {
        TwitchChatCard(model: model, delay: TwitchChatCard.tvDelay, fills: true)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - the list

private struct TwitchChannelList: View {
    let model: AppModel

    /// A stream playing in the pane beside this tab (its chat was put away for the list): offer it back.
    var besideStream: String? = nil
    var showChat: () -> Void = {}

    @Environment(Pane.self) private var pane
    @State private var query = ""

    private var store: TwitchStore { model.twitch }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if besideStream != nil {
                    Button(action: showChat) {
                        Label(Copy.Twitch.showChat, systemImage: Symbol.Twitch.chat)
                    }
                    .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                    .accessibilityIdentifier("twitch.showChat")
                }
                search
                banner
                if let me = store.session?.credentials?.login {
                    section(Copy.Twitch.yourChannel) {
                        TwitchRecentChip(login: me, icon: Symbol.Twitch.pin) { watch(me) }
                    }
                }
                live
                if !store.recents.isEmpty {
                    section(Copy.Twitch.recent) {
                        TwitchFlow(spacing: 8, lineSpacing: 8) {
                            ForEach(store.recents, id: \.self) { login in
                                TwitchRecentChip(login: login, icon: Symbol.Twitch.recent) { watch(login) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.load(force: true) }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: Symbol.Twitch.search).foregroundStyle(CobaltColor.caption)
            TextField(Copy.Twitch.searchPrompt, text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                #endif
                .onSubmit(openQuery)
                .accessibilityIdentifier("twitch.search")
            if TwitchStore.login(from: query) != nil {
                Button(Copy.Twitch.open, action: openQuery)
                    .buttonStyle(.cobaltPrimary(fullWidth: false, compact: true))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minHeight: Metrics.hit)
        .background(CobaltColor.surface, in: Capsule())
    }

    private func openQuery() {
        guard TwitchStore.login(from: query) != nil else { return }
        watch(query)
        query = ""
    }

    /// A channel opens in the pane (its page opens the chat and starts the player).
    private func watch(_ name: String) {
        guard let login = TwitchStore.login(from: name) else { return }
        pane.open(.stream(login))
    }

    @ViewBuilder private var banner: some View {
        if store.needsReconnect {
            TwitchBanner(title: Copy.Twitch.reconnectTitle, message: Copy.Twitch.reconnectBody) { model.selectedTab = .stage }
        } else if store.needsChatScopes {
            TwitchBanner(title: Copy.Twitch.scopesTitle, message: Copy.Twitch.scopesBody) { model.selectedTab = .stage }
        } else if store.sessionLoaded, store.session?.credentials == nil {
            TwitchBanner(title: Copy.Twitch.readOnlyTitle, message: Copy.Twitch.readOnlyBody) { model.selectedTab = .stage }
        }
    }

    @ViewBuilder private var live: some View {
        if store.session?.credentials != nil {
            section(Copy.Twitch.liveNow) {
                if !store.followingLoaded {
                    Text(Copy.Twitch.loading).foregroundStyle(CobaltColor.caption)
                } else if store.following.isEmpty {
                    Text(Copy.Twitch.noneLive).foregroundStyle(CobaltColor.caption)
                } else {
                    DuoAdaptiveGrid(minItemWidth: 250, spacing: 14, rowSpacing: 18, alignment: .leading) {
                        ForEach(store.following) { s in
                            Button { watch(s.login) } label: { TwitchStreamCard(stream: s) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Font.cobalt(12.5, .medium, relativeTo: .caption))
                .foregroundStyle(CobaltColor.caption)
            content()
        }
    }
}

private struct TwitchBanner: View {
    let title: String
    let message: String
    let openStudio: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: Symbol.Twitch.warn)
                .font(Font.cobalt(14.5, .semibold))
                .foregroundStyle(CobaltColor.text)
            Text(message)
                .font(Font.cobalt(13.5))
                .foregroundStyle(CobaltColor.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button(Copy.Twitch.openStudio, action: openStudio)
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TwitchChatPalette.twitch.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(TwitchChatPalette.twitch.opacity(0.35)))
    }
}

private struct TwitchRecentChip: View {
    let login: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(login, systemImage: icon)
                .font(Font.cobalt(13.5, .medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(CobaltColor.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CobaltColor.text)
    }
}

private struct TwitchStreamCard: View {
    let stream: TwitchStreamInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(CobaltColor.frameBase)
                if let url = stream.thumbnail { StillImage(url: url) }
                HStack(spacing: 5) {
                    Text(Copy.Twitch.live.uppercased())
                        .font(.system(size: 10.5, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
                    Label(Copy.Twitch.viewers(stream.viewers), systemImage: Symbol.Twitch.viewers)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(CobaltColor.badgeBack, in: RoundedRectangle(cornerRadius: 4))
                }
                .foregroundStyle(.white)
                .padding(7)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(stream.displayName)
                .font(Font.cobalt(14.5, .semibold))
                .foregroundStyle(CobaltColor.text)
            Text(stream.title)
                .font(Font.cobalt(13))
                .foregroundStyle(CobaltColor.caption)
                .lineLimit(2)
            if !stream.game.isEmpty {
                Text(stream.game)
                    .font(Font.cobalt(12))
                    .foregroundStyle(TwitchChatPalette.twitch)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}
