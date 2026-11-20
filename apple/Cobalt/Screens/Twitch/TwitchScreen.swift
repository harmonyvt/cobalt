import CobaltKit
import SwiftUI

// The twitch tab (APP-API-CONTRACT 70): a list of channels (search, your channel, who you follow that is live, recent),
// then one channel: Twitch's own player and its live chat. On a wide screen (an unfolded Duo, an iPad in landscape, the
// Mac) the player and chat sit side by side; on a phone the chat is under the player.

struct TwitchScreen: View {
    let model: AppModel
    let tier: Tier

    @State private var addingToSet: SevenTvAddToSetModel?

    private var store: TwitchStore { model.twitch }

    var body: some View {
        Group {
            if let channel = store.channel {
                TwitchWatchView(model: model, channel: channel, addingToSet: $addingToSet)
            } else {
                TwitchChannelList(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CobaltColor.bg)
        .navigationTitle(store.channel.map { store.channelInfo?.displayName ?? $0 } ?? Copy.Twitch.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if store.channel != nil {
                ToolbarItem(placement: .navigation) {
                    Button(Copy.Twitch.back, systemImage: Symbol.Twitch.back) { store.close() }
                }
            }
        }
        .task {
            await store.load()
            if model.sevenTv.status == nil { await model.sevenTv.load() }
        }
        .spreadSheet(item: $addingToSet) { picker in
            SevenTvAddToSetSheet(picker: picker)
        }
    }
}

// MARK: - the list

private struct TwitchChannelList: View {
    let model: AppModel

    @State private var query = ""

    private var store: TwitchStore { model.twitch }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                search
                banner
                if let me = store.session?.credentials?.login {
                    section(Copy.Twitch.yourChannel) {
                        TwitchRecentChip(login: me, icon: Symbol.Twitch.pin) { store.open(me) }
                    }
                }
                live
                if !store.recents.isEmpty {
                    section(Copy.Twitch.recent) {
                        TwitchFlow(spacing: 8, lineSpacing: 8) {
                            ForEach(store.recents, id: \.self) { login in
                                TwitchRecentChip(login: login, icon: Symbol.Twitch.recent) { store.open(login) }
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
        .refreshable { await store.loadFollowing() }
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
        store.open(query)
        query = ""
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], alignment: .leading, spacing: 18) {
                        ForEach(store.following) { s in
                            Button { store.open(s.login) } label: { TwitchStreamCard(stream: s) }
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

// MARK: - watching

private struct TwitchWatchView: View {
    let model: AppModel
    let channel: String
    @Binding var addingToSet: SevenTvAddToSetModel?

    private var store: TwitchStore { model.twitch }

    var body: some View {
        GeometryReader { geo in
            // side by side when there is room for a real chat column beside a 16:9 player
            if geo.size.width >= Spread.minWidth, geo.size.width > geo.size.height * 1.05 {
                let chatWidth = min(420, max(300, geo.size.width * 0.34))
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        TwitchPlayer(channel: channel)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                        TwitchInfoBar(model: model)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    HingeSeam(queue: model.queue)
                    chat.frame(width: chatWidth)
                }
            } else {
                VStack(spacing: 0) {
                    TwitchPlayer(channel: channel)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                    TwitchInfoBar(model: model, compact: true)
                    Divider()
                    chat
                }
            }
        }
    }

    private var chat: some View {
        TwitchChatPane(model: model) { emote in
            guard let hit = emote.asHit else { return }
            addingToSet = model.sevenTv.addToSetPicker(emote: hit)
        }
    }
}

private struct TwitchInfoBar: View {
    let model: AppModel
    var compact = false

    private var store: TwitchStore { model.twitch }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let avatar = store.channelInfo?.avatar {
                StillImage(url: avatar)
                    .frame(width: compact ? 30 : 40, height: compact ? 30 : 40)
                    .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(store.channelInfo?.displayName ?? store.channel ?? "")
                        .font(Font.cobalt(compact ? 14 : 16, .semibold))
                        .foregroundStyle(CobaltColor.text)
                    if let s = store.stream {
                        Label(Copy.Twitch.viewers(s.viewers), systemImage: Symbol.Twitch.viewers)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.red)
                    } else if store.channelInfo != nil {
                        Text(Copy.Twitch.offline)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(CobaltColor.caption)
                    }
                }
                if let s = store.stream {
                    Text(compact ? s.title : [s.title, s.game].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Font.cobalt(12.5))
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(compact ? 1 : 2)
                }
                if let note = clipNote {
                    Text(note)
                        .font(Font.cobalt(12, .medium))
                        .foregroundStyle(store.clipState == .failed ? CobaltColor.errorText : CobaltColor.success)
                }
            }
            Spacer(minLength: 0)
            if store.canClip {
                Button(Copy.Twitch.clip, systemImage: Symbol.Twitch.clip) {
                    Task { await store.clip { url in _ = model.queue.add([.link(url)], via: .paste) } }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                .disabled(store.clipState == .making)
                .help(Copy.Twitch.clip)
            }
            if let channel = store.channel, let url = URL(string: "https://www.twitch.tv/\(channel)") {
                Link(destination: url) {
                    Image(systemName: Symbol.Twitch.open)
                        .frame(width: Metrics.hit, height: Metrics.hit)
                }
                .foregroundStyle(CobaltColor.caption)
                .help(Copy.Twitch.openOnTwitch)
                .accessibilityLabel(Copy.Twitch.openOnTwitch)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 6 : 10)
        .task(id: store.clipState) {
            guard store.clipState == .saved || store.clipState == .failed else { return }
            try? await Task.sleep(for: .seconds(4))
            store.acknowledgeClip()
        }
    }

    private var clipNote: String? {
        switch store.clipState {
        case .idle: return nil
        case .making: return Copy.Twitch.clipping
        case .saved: return Copy.Twitch.clipSaved
        case .failed: return Copy.Twitch.clipFailed
        }
    }
}
