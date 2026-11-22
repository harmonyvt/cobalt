import CobaltKit
import SwiftUI

// The composer's emote picker (APP-API-CONTRACT 70.6): every emote the open channel offers, one section per source
// (`TwitchEmoteList.pickerSections`: this channel's 7TV set, this channel's Twitch emotes with the sub emotes the user
// lacks locked, the user's other Twitch emotes, Twitch global, 7TV global), "recent" on top, a filter and a row of
// section jumps. A tap puts the emote's name in the message; the picker stays open for more. Long press: copy the
// name, or add a 7TV emote to a set.

struct TwitchEmotePicker: View {
    let store: TwitchStore
    let canAddToSet: Bool
    let onAddEmote: (ChatEmote) -> Void
    let onPick: (ChatEmote) -> Void

    @State private var filter = ""

    private static let recentID = "recent"

    private struct Shown: Identifiable {
        var id: String
        var title: String
        var emotes: [ChatEmote]
        var locked: Set<String>
    }

    private var channelName: String { store.channelInfo?.displayName ?? store.channel ?? "" }

    private static let tile: CGFloat = 34
    private let columns = [GridItem(.adaptive(minimum: 52, maximum: 72), spacing: 4)]

    /// Recent (no filter), then each section with an emote matching the filter.
    private var sections: [Shown] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        var out: [Shown] = []
        if needle.isEmpty {
            let recent = store.recentEmotesHere
            if !recent.isEmpty { out.append(Shown(id: Self.recentID, title: Copy.Twitch.emotesRecent, emotes: recent, locked: [])) }
        }
        for s in store.emotes.sections(matching: needle) {
            out.append(Shown(id: s.id, title: title(s.kind), emotes: s.emotes, locked: s.locked))
        }
        return out
    }

    private func title(_ kind: TwitchEmoteSection.Kind) -> String {
        switch kind {
        case .channelSevenTv: return Copy.Twitch.emotesChannelSevenTv(channelName)
        case .channelTwitch: return Copy.Twitch.emotesChannelTwitch(channelName)
        case .yourTwitch: return Copy.Twitch.emotesYours
        case .twitchGlobal: return Copy.Twitch.emotesTwitchGlobal
        case .sevenTvGlobal: return Copy.Twitch.emotesGlobal
        }
    }

    private var emptyText: String {
        if !filter.trimmingCharacters(in: .whitespaces).isEmpty { return Copy.Twitch.emotesNone }
        // the sections arrive with the first emote list; until then they are still loading
        return store.emotes.sections.isEmpty ? Copy.Twitch.emotesLoading : Copy.Twitch.emotesEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: Symbol.Twitch.search)
                    .foregroundStyle(CobaltColor.caption)
                TextField(Copy.Twitch.emoteFilter, text: $filter)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            .font(Font.cobalt(13.5))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(CobaltColor.surface, in: Capsule())
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            let shown = sections
            if shown.isEmpty {
                Text(emptyText)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        if shown.count > 1 { jumps(shown, proxy: proxy) }
                        ScrollView {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                                ForEach(shown) { section in
                                    Section {
                                        ForEach(section.emotes, id: \.self) { emote in
                                            tile(emote, locked: section.locked.contains(emote.id))
                                        }
                                    } header: {
                                        header(section.title, count: section.emotes.count)
                                            .id(section.id)
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        }
                        .scrollDismissesKeyboard(.immediately)
                    }
                }
            }
        }
        .background(CobaltColor.bg)
        .accessibilityIdentifier("twitch.emotePicker")
    }

    /// One button per section (its first emote, a clock for recent): tap to scroll there.
    private func jumps(_ shown: [Shown], proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(shown) { section in
                    Button {
                        withAnimation(.snappy) { proxy.scrollTo(section.id, anchor: .top) }
                    } label: {
                        Group {
                            if section.id == Self.recentID {
                                Image(systemName: Symbol.Twitch.recent)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(CobaltColor.caption)
                            } else if let first = section.emotes.first {
                                EmotePicture(url: first.url, animated: false, side: 20)
                            }
                        }
                        .frame(width: 32, height: 28)
                        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                    #if os(macOS)
                    .help(section.title)
                    #endif
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 4)
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .lineLimit(1)
                .font(Font.cobalt(11.5, .semibold))
                .foregroundStyle(CobaltColor.caption)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(Font.cobalt(11))
                .foregroundStyle(CobaltColor.caption)
                .monospacedDigit()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(CobaltColor.bg)
    }

    private func tile(_ emote: ChatEmote, locked: Bool) -> some View {
        Button {
            guard !locked else { return }
            onPick(emote)
        } label: {
            VStack(spacing: 2) {
                EmotePicture(url: emote.url, animated: emote.animated, side: Self.tile)
                    .opacity(locked ? 0.35 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if locked {
                            Image(systemName: Symbol.Twitch.locked)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(CobaltColor.caption)
                        }
                    }
                Text(emote.name)
                    .font(Font.cobalt(9.5))
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(locked ? "\(emote.name), \(Copy.Twitch.locked)" : emote.name)
        #if os(macOS)
        .help(locked ? "\(emote.name) · \(Copy.Twitch.locked)" : emote.name)
        #endif
        .contextMenu {
            Section(locked ? "\(emote.name) · \(Copy.Twitch.locked)" : emote.name) {
                Button(Copy.Twitch.copyName, systemImage: Symbol.Twitch.copy) { TwitchPasteboard.copy(emote.name) }
                if canAddToSet, emote.asHit != nil {
                    Button(Copy.Twitch.addToSet, systemImage: Symbol.SevenTv.add) { onAddEmote(emote) }
                }
            }
        }
    }
}
