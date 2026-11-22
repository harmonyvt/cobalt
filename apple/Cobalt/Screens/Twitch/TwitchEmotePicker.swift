import CobaltKit
import SwiftUI

// The emote picker (APP-API-CONTRACT 70.6): every emote the open channel offers, grouped by where it comes from (this
// channel's 7TV set, this channel's Twitch emotes, the user's other Twitch emotes, Twitch global, 7TV global), with a
// search, a row of section jumps and the message being written, so emotes can be stacked up and sent from here.
// A popover on the Mac and iPad, a sheet on the iPhone. Built from `TwitchStore.emotes`; nothing new is fetched.

struct TwitchEmotePicker: View {
    let store: TwitchStore
    @Binding var draft: String
    let canSend: Bool
    let canAddToSet: Bool
    let onPick: (ChatEmote) -> Void
    let onSend: () -> Void
    let onAddEmote: (ChatEmote) -> Void
    let onDone: () -> Void

    @State private var query = ""

    private static let recentID = "recent"

    private var channelName: String { store.channelInfo?.displayName ?? store.channel ?? "" }

    /// What the grid shows: recent first (no search), then each non-empty section.
    private var shown: [PickerGroup] {
        var out: [PickerGroup] = []
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let recent = store.recentEmotesHere
            if !recent.isEmpty { out.append(PickerGroup(id: Self.recentID, title: Copy.Twitch.recentEmotes, emotes: recent, locked: [])) }
        }
        for s in store.emotes.sections(matching: trimmed) {
            out.append(PickerGroup(id: s.id, title: title(s.kind), emotes: s.emotes, locked: s.locked))
        }
        return out
    }

    private func title(_ kind: TwitchEmoteSection.Kind) -> String {
        switch kind {
        case .channelSevenTv: return Copy.Twitch.channelSevenTv(channelName)
        case .channelTwitch: return Copy.Twitch.channelTwitch(channelName)
        case .yourTwitch: return Copy.Twitch.yourTwitch
        case .twitchGlobal: return Copy.Twitch.twitchGlobal
        case .sevenTvGlobal: return Copy.Twitch.sevenTvGlobal
        }
    }

    var body: some View {
        let groups = shown
        VStack(spacing: 0) {
            #if os(iOS)
            titleRow
            #endif
            searchField
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if groups.count > 1 { jumps(groups, proxy: proxy) }
                    grid(groups)
                }
            }
            draftBar
        }
        .background(CobaltColor.bg)
    }

    // MARK: - parts

    private var titleRow: some View {
        HStack {
            Text(Copy.Twitch.emotes)
                .font(Font.cobalt(15, .semibold))
                .foregroundStyle(CobaltColor.text)
            Spacer(minLength: 0)
            Button(Copy.Twitch.done, action: onDone)
                .font(Font.cobalt(14, .semibold))
                .foregroundStyle(TwitchChatPalette.twitch)
                .buttonStyle(.plain)
                .frame(minHeight: 36)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: Symbol.Twitch.search)
                .foregroundStyle(CobaltColor.caption)
            TextField(Copy.Twitch.emoteSearch, text: $query)
                .textFieldStyle(.plain)
                .font(Font.cobalt(14))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
            if !query.isEmpty {
                Button(Copy.Twitch.cancelReply, systemImage: Symbol.Twitch.close) { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(CobaltColor.caption)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(CobaltColor.surface, in: Capsule())
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// One button per group, its first emote as the icon: tap to scroll there.
    private func jumps(_ groups: [PickerGroup], proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(groups) { g in
                    Button {
                        withAnimation(.snappy) { proxy.scrollTo(g.id, anchor: .top) }
                    } label: {
                        PickerGroup.icon(g)
                            .frame(width: 34, height: 30)
                            .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(g.title)
                    .accessibilityLabel(g.title)
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private func grid(_ groups: [PickerGroup]) -> some View {
        if groups.isEmpty {
            VStack {
                Spacer(minLength: 0)
                Text(emptyText)
                    .font(Font.cobalt(13))
                    .foregroundStyle(CobaltColor.caption)
                    .multilineTextAlignment(.center)
                    .padding(24)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { g in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 60), spacing: 2)], spacing: 2) {
                                ForEach(g.emotes, id: \.self) { emote in
                                    tile(emote, locked: g.locked.contains(emote.id))
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 10)
                        } header: {
                            header(g)
                        }
                        .id(g.id)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var emptyText: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return Copy.Twitch.emotesMiss(q) }
        // the sections arrive with the first emote list; until then they are still loading
        return store.emotes.sections.isEmpty ? Copy.Twitch.emotesLoading : Copy.Twitch.emotesNone
    }

    private func header(_ g: PickerGroup) -> some View {
        HStack(spacing: 6) {
            Text(g.title)
                .font(Font.cobalt(12, .semibold))
                .foregroundStyle(CobaltColor.caption)
                .lineLimit(1)
            Text("\(g.emotes.count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(CobaltColor.caption.opacity(0.7))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(CobaltColor.bg)
    }

    private func tile(_ emote: ChatEmote, locked: Bool) -> some View {
        Button {
            guard !locked else { return }
            onPick(emote)
        } label: {
            EmotePicture(url: emote.url, animated: emote.animated, side: 32)
                .frame(width: 44, height: 44)
                .opacity(locked ? 0.35 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if locked {
                        Image(systemName: Symbol.Twitch.locked)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(CobaltColor.caption)
                            .padding(4)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(locked ? "\(emote.name) · \(Copy.Twitch.locked)" : emote.name)
        .accessibilityLabel(locked ? "\(emote.name), \(Copy.Twitch.locked)" : emote.name)
        .contextMenu {
            Section(locked ? "\(emote.name) · \(Copy.Twitch.locked)" : emote.name) {
                Button(Copy.Twitch.copyName, systemImage: Symbol.Twitch.copy) { TwitchPasteboard.copy(emote.name) }
                if canAddToSet, emote.asHit != nil {
                    Button(Copy.Twitch.addToSet, systemImage: Symbol.SevenTv.add) { onAddEmote(emote) }
                }
            }
        }
    }

    /// The message being written, so emotes can be stacked up and sent without leaving the picker.
    private var draftBar: some View {
        HStack(spacing: 8) {
            TextField(canSend ? Copy.Twitch.composerPrompt : Copy.Twitch.composerReadOnly, text: $draft)
                .textFieldStyle(.plain)
                .font(Font.cobalt(14))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.send)
                #endif
                .disabled(!canSend)
                .onSubmit(onSend)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(CobaltColor.surface, in: Capsule())
            Button(Copy.Twitch.send, systemImage: Symbol.Twitch.send, action: onSend)
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(sendable ? TwitchChatPalette.twitch : CobaltColor.elevated, in: Circle())
                .buttonStyle(.plain)
                .disabled(!sendable)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }

    private var sendable: Bool { canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - a group on screen

    fileprivate struct PickerGroup: Identifiable {
        var id: String
        var title: String
        var emotes: [ChatEmote]
        var locked: Set<String>

        @ViewBuilder static func icon(_ g: PickerGroup) -> some View {
            if g.id == TwitchEmotePicker.recentID {
                Image(systemName: Symbol.Twitch.recent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CobaltColor.caption)
            } else if let first = g.emotes.first {
                EmotePicture(url: first.url, animated: false, side: 22)
            }
        }
    }
}
