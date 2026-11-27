import CobaltKit
import SwiftUI

// The twitch tab (APP-API-CONTRACT 70; CONTRACT-PANE section 5): always the channel browser (search, your channel, who
// you follow that is live, recent). Tapping a channel opens or switches the stream in the screen pane (`TwitchStreamPage`),
// which keeps playing in the bar when closed and stays consistent across every device posture (folded, Duo wide/tall,
// iPad, Mac) and tab switch.

struct TwitchScreen: View {
    let model: AppModel
    let tier: Tier

    @Environment(\.lifecycle) private var lifecycle
    @Environment(Pane.self) private var pane

    private var store: TwitchStore { model.twitch }

    /// All channels currently held by the pane (single or dual, on screen, spanned, or minimized in the bar).
    private var activeLogins: Set<String> {
        var logins: Set<String> = []
        if let item = pane.item, pane.state != .hidden {
            logins.formUnion(item.streamChannels.map { $0.lowercased() })
        }
        if let bar = pane.barItem {
            logins.formUnion(bar.streamChannels.map { $0.lowercased() })
        }
        return logins
    }

    /// The stream item currently active in the pane or bar, used for 1-tap "watch alongside" promotion (1->2->3->4).
    private var currentStreamItem: PaneItem? {
        if let item = pane.item, pane.state != .hidden, item.isStream {
            return item
        }
        if let bar = pane.barItem, bar.isStream {
            return bar
        }
        return nil
    }

    var body: some View {
        TwitchChannelList(
            model: model,
            activeLogins: activeLogins,
            currentStreamItem: currentStreamItem
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(CobaltColor.bg)
            .navigationTitle(Copy.Twitch.title)
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
    }
}

// MARK: - the list

private struct TwitchChannelList: View {
    let model: AppModel
    var activeLogins: Set<String>
    var currentStreamItem: PaneItem?

    @Environment(Pane.self) private var pane
    @State private var query = ""
    @State private var pickingAlongsideFor: String?

    private var store: TwitchStore { model.twitch }

    private func isWatching(_ login: String) -> Bool {
        activeLogins.contains(login.lowercased())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                search
                banner
                if let me = store.session?.credentials?.login {
                    section(Copy.Twitch.yourChannel) {
                        TwitchRecentChip(login: me, icon: Symbol.Twitch.pin, active: isWatching(me)) { watch(me) }
                            .contextMenu { alongsideMenuItems(for: me) }
                    }
                }
                live
                if !store.recents.isEmpty {
                    section(Copy.Twitch.recent) {
                        TwitchFlow(spacing: 8, lineSpacing: 8) {
                            ForEach(store.recents, id: \.self) { login in
                                TwitchRecentChip(login: login, icon: Symbol.Twitch.recent, active: isWatching(login)) { watch(login) }
                                    .contextMenu { alongsideMenuItems(for: login) }
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
        .sheet(item: Binding(
            get: { pickingAlongsideFor.map(AlongsidePickTarget.init(login:)) },
            set: { pickingAlongsideFor = $0?.login }
        )) { target in
            TwitchAddSecondStreamSheet(
                model: model,
                excluding: [target.login.lowercased()]
            ) { partner in
                pane.open(.dualStream(primary: target.login, secondary: partner))
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
        }
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
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .frame(minHeight: Metrics.hit)
        .background(CobaltColor.surface, in: Capsule())
        .overlay {
            Capsule().strokeBorder(CobaltColor.hairline, lineWidth: 0.75)
        }
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

    /// Promotes an active stream session by adding `name` (1->2->3->4), or asks for a 2nd stream if none is active yet.
    private func watchAlongside(_ name: String) {
        guard let login = TwitchStore.login(from: name) else { return }
        if let existing = currentStreamItem {
            let channels = existing.streamChannels
            if channels.contains(where: { $0.caseInsensitiveCompare(login) == .orderedSame }) {
                pane.open(existing)
            } else if channels.count < PaneItem.maxSimultaneousStreams {
                if let next = existing.addingStream(login) { pane.open(next) }
            } else if let next = existing.replacingStream(at: PaneItem.maxSimultaneousStreams - 1, with: login) {
                pane.open(next)
            }
        } else {
            pickingAlongsideFor = login
        }
    }

    @ViewBuilder
    private func alongsideMenuItems(for login: String) -> some View {
        Button {
            watch(login)
        } label: {
            Label(Copy.Twitch.open, systemImage: Symbol.Twitch.tab)
        }
        if !isWatching(login) {
            let labelText: String = {
                if let existing = currentStreamItem, existing.streamChannels.count >= 2,
                   existing.streamChannels.count < PaneItem.maxSimultaneousStreams {
                    return Copy.Twitch.addStreamTitle(current: existing.streamChannels.count, max: PaneItem.maxSimultaneousStreams)
                }
                return Copy.Twitch.watchAlongside
            }()
            Button {
                watchAlongside(login)
            } label: {
                Label(labelText, systemImage: Symbol.Twitch.watchAlongside)
            }
        }
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
                            let watching = isWatching(s.login)
                            let canAddDual = currentPrimaryLogin != nil && !watching
                            TwitchStreamCard(
                                stream: s,
                                watching: watching,
                                onWatch: { watch(s.login) },
                                onAddDual: canAddDual ? { watchAlongside(s.login) } : nil
                            )
                            .contextMenu { alongsideMenuItems(for: s.login) }
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

private struct AlongsidePickTarget: Identifiable {
    let login: String
    var id: String { login }
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
        .background(TwitchChatPalette.twitch.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TwitchChatPalette.twitch.opacity(0.35)))
    }
}

private struct TwitchRecentChip: View {
    let login: String
    let icon: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Label(login, systemImage: icon)
                if active {
                    Circle()
                        .fill(TwitchChatPalette.twitch)
                        .frame(width: 6, height: 6)
                        .shadow(color: TwitchChatPalette.twitch.opacity(0.65), radius: 3)
                        .accessibilityHidden(true)
                }
            }
            .font(Font.cobalt(13.5, .medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(active ? TwitchChatPalette.twitch.opacity(0.14) : CobaltColor.surface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    active ? TwitchChatPalette.twitch.opacity(0.55) : CobaltColor.hairline,
                    lineWidth: active ? 1 : 0.75
                )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(CobaltColor.text)
        .accessibilityValue(active ? Copy.Twitch.watchingNow : "")
    }
}

private struct TwitchStreamCard: View {
    let stream: TwitchStreamInfo
    var watching = false
    let onWatch: () -> Void
    var onAddDual: (() -> Void)? = nil

    private var uptimeText: String? {
        guard let started = stream.startedAt else { return nil }
        let elapsed = max(0, Int(Date.now.timeIntervalSince(started)))
        guard elapsed >= 60 else { return nil }
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Button(action: onWatch) {
                    ZStack {
                        Rectangle().fill(CobaltColor.frameBase)
                        if let url = stream.thumbnail { StillImage(url: url) }

                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            MediaEdgeVignette(edge: .bottom, height: 48, intensity: 0.48)
                        }
                        .allowsHitTesting(false)

                        VStack(spacing: 0) {
                            HStack(spacing: 6) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 6, height: 6)
                                        .shadow(color: .red.opacity(0.75), radius: 2.5)
                                    Text(Copy.Twitch.live.uppercased())
                                        .font(.system(size: 10, weight: .bold))
                                    Text("·")
                                        .font(.system(size: 10, weight: .semibold))
                                        .opacity(0.65)
                                    Text(Copy.Twitch.viewers(stream.viewers))
                                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .mediaGlassCapsule(interactive: false)

                                if watching {
                                    Text(Copy.Twitch.watchingNow)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .mediaGlassCapsule(interactive: false, tint: TwitchChatPalette.twitch)
                                }
                                Spacer(minLength: 0)
                            }

                            Spacer(minLength: 0)

                            if let uptimeText {
                                HStack {
                                    Text(uptimeText)
                                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.92))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .mediaGlassCapsule(interactive: false)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                watching ? TwitchChatPalette.twitch : Color.white.opacity(0.10),
                                lineWidth: watching ? 2 : 0.75
                            )
                    }
                }
                .buttonStyle(.plain)

                // Sibling button (never nested inside the watch button) for 1-tap dual-stream promotion.
                if let onAddDual {
                    VStack {
                        Spacer(minLength: 0)
                        HStack {
                            Spacer(minLength: 0)
                            Button(action: onAddDual) {
                                HStack(spacing: 4) {
                                    Image(systemName: Symbol.Twitch.addStream)
                                        .font(.system(size: 10.5, weight: .bold))
                                    Text("Dual")
                                        .font(Font.cobalt(11, .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .mediaGlassCapsule()
                                .frame(minWidth: Metrics.hit, minHeight: Metrics.hit, alignment: .bottomTrailing)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(Copy.Twitch.watchAlongside) \(stream.displayName)")
                            .accessibilityIdentifier("twitch.card.addDual.\(stream.login)")
                            .padding(6)
                        }
                    }
                }
            }

            Button(action: onWatch) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.displayName)
                        .font(Font.cobalt(14.5, .semibold))
                        .foregroundStyle(CobaltColor.text)
                    Text(stream.title)
                        .font(Font.cobalt(13))
                        .foregroundStyle(CobaltColor.caption)
                        .lineLimit(2)
                    if !stream.game.isEmpty {
                        Text(stream.game)
                            .font(Font.cobalt(12, .medium))
                            .foregroundStyle(TwitchChatPalette.twitch)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
