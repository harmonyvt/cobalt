import CobaltKit
import SwiftUI

// The composer's emote picker (APP-API-CONTRACT 70): every emote chat knows for the open channel, in the order chat
// completes them (the channel's 7TV set, the signed-in user's Twitch emotes, 7TV global), with a filter on top. A tap
// puts the emote's name in the message; the picker stays open for more.

struct TwitchEmotePicker: View {
    let list: TwitchEmoteList
    let onPick: (ChatEmote) -> Void

    @State private var filter = ""

    private static let tile: CGFloat = 34
    private let columns = [GridItem(.adaptive(minimum: 52, maximum: 72), spacing: 4)]

    /// The emotes in the order chat ranks them, one section per source, a name only once (the first source wins).
    private var sections: [(ChatEmote.Source, [ChatEmote])] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var seen = Set<String>()
        var bySource: [ChatEmote.Source: [ChatEmote]] = [:]
        for emote in list.emotes {
            guard needle.isEmpty || emote.name.lowercased().contains(needle) else { continue }
            guard seen.insert(emote.name).inserted else { continue }
            bySource[emote.source, default: []].append(emote)
        }
        return [ChatEmote.Source.sevenTv, .twitch, .sevenTvGlobal].compactMap { source in
            guard let emotes = bySource[source], !emotes.isEmpty else { return nil }
            return (source, emotes)
        }
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
                Text(list.emotes.isEmpty ? Copy.Twitch.emotesLoading : Copy.Twitch.emotesNone)
                    .font(CobaltType.caption)
                    .foregroundStyle(CobaltColor.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                        ForEach(shown, id: \.0) { source, emotes in
                            Section {
                                ForEach(emotes) { emote in
                                    tile(emote)
                                }
                            } header: {
                                header(source, count: emotes.count)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .background(CobaltColor.bg)
        .accessibilityIdentifier("twitch.emotePicker")
    }

    private static func title(_ source: ChatEmote.Source) -> String {
        switch source {
        case .sevenTv: return Copy.Twitch.emotesChannel
        case .twitch: return Copy.Twitch.emotesYours
        case .sevenTvGlobal: return Copy.Twitch.emotesGlobal
        }
    }

    private func header(_ source: ChatEmote.Source, count: Int) -> some View {
        HStack {
            Text(Self.title(source))
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

    private func tile(_ emote: ChatEmote) -> some View {
        Button { onPick(emote) } label: {
            VStack(spacing: 2) {
                EmotePicture(url: emote.url, animated: emote.animated, side: Self.tile)
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
        .accessibilityLabel(emote.name)
        #if os(macOS)
        .help(emote.name)
        #endif
    }
}
