import CobaltKit
import SwiftUI

// The composer's emote picker (APP-API-CONTRACT 70.6): every emote the open channel offers, one section per source
// (`TwitchEmoteList.pickerSections`: this channel's 7TV set, this channel's Twitch emotes with the sub emotes the user
// lacks locked, the user's other Twitch emotes, Twitch global, 7TV global), "recent" on top, a filter and labeled
// category jump pills. A tap puts the emote's name in the message; the picker stays open for more. Long press: copy the
// name, or add a 7TV emote to a set.

struct TwitchEmotePicker: View {
    let store: TwitchStore
    let canAddToSet: Bool
    var emotesOverride: TwitchEmoteList? = nil
    var recentOverride: [ChatEmote]? = nil
    var channelNameOverride: String? = nil
    let onAddEmote: (ChatEmote) -> Void
    let onPick: (ChatEmote) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var filter = ""
    @State private var gridWidth: CGFloat = 0
    @State private var isScrolling = false
    @State private var shownSections: [Shown] = []
    @State private var selectedSectionID: String?

    private static let recentID = "recent"

    private struct Shown: Identifiable {
        var id: String
        var title: String
        var pillTitle: String
        var emotes: [ChatEmote]
        var locked: Set<String>
    }

    private struct FilterKey: Equatable {
        let filter: String
        let emotes: TwitchEmoteList
        let recents: [ChatEmote]
        let channelName: String
    }

    private var activeEmotes: TwitchEmoteList { emotesOverride ?? store.emotes }
    private var activeRecents: [ChatEmote] { recentOverride ?? store.recentEmotesHere }
    private var channelName: String { channelNameOverride ?? store.channelInfo?.displayName ?? store.channel ?? "" }

    private var isWide: Bool { gridWidth >= 560 || sizeClass == .regular }
    private var tileImageSize: CGFloat { isWide ? 38 : 34 }

    private var columns: [GridItem] {
        let minWidth: CGFloat = isWide ? 68 : 60
        if gridWidth > 0 {
            return DuoGrid.gridItems(
                forWidth: gridWidth,
                minItemWidth: minWidth,
                spacing: 6,
                sizeClass: sizeClass,
                minColumns: 4
            )
        }
        return DuoGrid.fixedGridItems(compact: 5, regular: 8, spacing: 6, sizeClass: sizeClass)
    }

    private var filterKey: FilterKey {
        FilterKey(filter: filter, emotes: activeEmotes, recents: activeRecents, channelName: channelName)
    }

    private var totalMatches: Int {
        shownSections.reduce(0) { $0 + $1.emotes.count }
    }

    /// Recomputes visible sections only when filter text, emote list, recents, or channel name actually change.
    private func recomputeSections() -> [Shown] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        var out: [Shown] = []
        if needle.isEmpty {
            let recent = activeRecents
            if !recent.isEmpty {
                out.append(Shown(
                    id: Self.recentID,
                    title: Copy.Twitch.emotesRecent,
                    pillTitle: Copy.Twitch.emotesRecent,
                    emotes: recent,
                    locked: []
                ))
            }
        }
        for s in activeEmotes.sections(matching: needle) {
            out.append(Shown(
                id: s.id,
                title: title(s.kind),
                pillTitle: pillTitle(s.kind),
                emotes: s.emotes,
                locked: s.locked
            ))
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

    private func pillTitle(_ kind: TwitchEmoteSection.Kind) -> String {
        switch kind {
        case .channelSevenTv: return "7tv"
        case .channelTwitch: return channelName.isEmpty ? "channel" : channelName
        case .yourTwitch: return "yours"
        case .twitchGlobal: return "twitch"
        case .sevenTvGlobal: return "7tv global"
        }
    }

    private var emptyText: String {
        if !filter.trimmingCharacters(in: .whitespaces).isEmpty { return Copy.Twitch.emotesNone }
        // the sections arrive with the first emote list; until then they are still loading
        return activeEmotes.sections.isEmpty ? Copy.Twitch.emotesLoading : Copy.Twitch.emotesEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                topBar(proxy: proxy)

                if shownSections.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: Symbol.Twitch.emotes)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(CobaltColor.caption.opacity(0.6))
                        Text(emptyText)
                            .font(CobaltType.caption)
                            .foregroundStyle(CobaltColor.caption)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                            ForEach(shownSections) { section in
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
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            if abs(width - gridWidth) > 1 {
                                gridWidth = width
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .onScrollPhaseChange { _, newPhase in
                        let scrolling = newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
                        if isScrolling != scrolling {
                            isScrolling = scrolling
                        }
                    }
                }
            }
        }
        .background(CobaltColor.bg)
        .onChange(of: filterKey, initial: true) { _, _ in
            shownSections = recomputeSections()
            if let current = selectedSectionID, !shownSections.contains(where: { $0.id == current }) {
                selectedSectionID = shownSections.first?.id
            } else if selectedSectionID == nil {
                selectedSectionID = shownSections.first?.id
            }
        }
        .accessibilityIdentifier("twitch.emotePicker")
    }

    /// On wide screens, places the search input and category pills on one sleek row; on compact widths, stacks them cleanly.
    @ViewBuilder
    private func topBar(proxy: ScrollViewProxy) -> some View {
        if isWide {
            HStack(spacing: 8) {
                searchField
                    .frame(width: 220)
                if shownSections.count > 1 {
                    categoryPills(shownSections, proxy: proxy)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider() }
        } else {
            VStack(spacing: 6) {
                searchField
                    .padding(.horizontal, 10)
                if shownSections.count > 1 {
                    categoryPills(shownSections, proxy: proxy)
                        .padding(.horizontal, 10)
                }
            }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: Symbol.Twitch.search)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(CobaltColor.caption)
            TextField(Copy.Twitch.emoteFilter, text: $filter)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !filter.isEmpty {
                Text("\(totalMatches)")
                    .font(Font.cobalt(11, .medium).monospacedDigit())
                    .foregroundStyle(CobaltColor.caption)
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(CobaltColor.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .font(Font.cobalt(13.5))
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(CobaltColor.surface, in: Capsule())
        .overlay {
            Capsule().strokeBorder(CobaltColor.hairline, lineWidth: 0.75)
        }
    }

    /// Scrollable labeled category jump pills with icon/preview + count + active selection highlight.
    private func categoryPills(_ shown: [Shown], proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(shown) { section in
                    let isSelected = (selectedSectionID ?? shown.first?.id) == section.id
                    Button {
                        selectedSectionID = section.id
                        withAnimation(.snappy(duration: 0.22)) {
                            proxy.scrollTo(section.id, anchor: .top)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if section.id == Self.recentID {
                                Image(systemName: Symbol.Twitch.recent)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(isSelected ? TwitchChatPalette.twitch : CobaltColor.caption)
                            } else if let first = section.emotes.first {
                                EmotePicture(url: first.url, animated: false, side: 18)
                            }
                            Text(section.pillTitle)
                                .font(Font.cobalt(12, isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? CobaltColor.text : CobaltColor.caption)
                                .lineLimit(1)
                            Text("\(section.emotes.count)")
                                .font(Font.cobalt(10.5, .medium).monospacedDigit())
                                .foregroundStyle(isSelected ? TwitchChatPalette.twitch : CobaltColor.caption.opacity(0.75))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(
                            isSelected ? TwitchChatPalette.twitch.opacity(0.16) : CobaltColor.surface,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().strokeBorder(
                                isSelected ? TwitchChatPalette.twitch.opacity(0.65) : CobaltColor.hairline,
                                lineWidth: isSelected ? 1 : 0.75
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    #if os(macOS)
                    .help(section.title)
                    #endif
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .font(Font.cobalt(11.5, .semibold))
                .foregroundStyle(CobaltColor.caption)
            Text("\(count)")
                .font(Font.cobalt(10.5, .medium).monospacedDigit())
                .foregroundStyle(CobaltColor.caption.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(CobaltColor.surface, in: Capsule())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(CobaltColor.bg.opacity(0.96))
    }

    private func tile(_ emote: ChatEmote, locked: Bool) -> some View {
        Button {
            guard !locked else { return }
            onPick(emote)
        } label: {
            VStack(spacing: 4) {
                EmotePicture(url: emote.url, animated: emote.animated && !isScrolling, side: tileImageSize)
                    .opacity(locked ? 0.35 : 1)
                Text(emote.name)
                    .font(Font.cobalt(10, .medium))
                    .foregroundStyle(locked ? CobaltColor.caption.opacity(0.55) : CobaltColor.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: isWide ? 64 : 58)
            .background(
                CobaltColor.surface.opacity(locked ? 0.45 : 0.72),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(CobaltColor.hairline.opacity(0.65), lineWidth: 0.5)
            }
            .overlay(alignment: .topTrailing) {
                if locked {
                    Image(systemName: Symbol.Twitch.locked)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(CobaltColor.caption)
                        .padding(4)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
