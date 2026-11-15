import CobaltKit
import SwiftUI

/// The one shelf over the mosaic (2026-11-15; it was three stacked shelves: edits, recent links, collection pills). Its
/// header is three quiet tabs, `links 36 · edits 41 · collections 12` (only the ones that have something), with `see all`
/// and a fold chevron at the end; under it one row of cards, every card the same 72 pt height whichever tab is on, so
/// switching tabs never moves the tiles. Folded, only the header line stays. The tab and the fold are remembered on the
/// device. A link card copies its link (`see all` opens the links tab), an edit card opens the edit, a collection card
/// opens the collection. It scrolls with the tiles; hidden while selecting or searching, and when there is nothing in it.
///
/// While the library's first page loads the shelf holds its place with grey cards (`placeholder`), but only on a device
/// that has shown the shelf before: a library with no links or edits never flashes one.
struct LibraryShelves: View {
    let model: AppModel
    let controller: LibraryController
    /// Grey cards in the shelf's place (the library is loading).
    var placeholder = false

    enum Tab: String, CaseIterable, Identifiable {
        case links, edits, collections
        var id: String { rawValue }
    }

    @AppStorage("library.shelf.tab") private var tabRaw = Tab.links.rawValue
    @AppStorage("library.shelf.folded") private var folded = false
    @AppStorage(LibraryShelves.seenKey) private var seen = false

    @Environment(\.shell) private var shell

    private var store: ShareSetStore { model.shareSets }

    /// The link cards: the newest links (the links tab has the rest).
    static let cardLimit = 12
    /// Every card's height, on every tab.
    static let cardHeight: CGFloat = 72
    /// Set once the shelf has shown real cards on this device (the placeholder only stands in for a shelf that exists).
    static let seenKey = "library.shelf.seen"

    /// Whether the shelves have anything to show for this model.
    static func hasContent(_ model: AppModel) -> Bool { !tabs(model).isEmpty }

    /// Whether this device has shown the shelf before (so a loading library may hold its place).
    static var wasSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    /// The tabs with something in them, in the header's order.
    static func tabs(_ model: AppModel) -> [Tab] {
        var out: [Tab] = []
        if model.capabilities.shareSets, !model.shareSets.sets.isEmpty { out.append(.links) }
        if LibraryEditsShelf.shows(model) { out.append(.edits) }
        if model.capabilities.shareCollections, !model.shareSets.collections.isEmpty { out.append(.collections) }
        return out
    }

    /// The remembered tab, or the first one that has something.
    private func current(in tabs: [Tab]) -> Tab {
        let saved = Tab(rawValue: tabRaw) ?? .links
        return tabs.contains(saved) ? saved : (tabs.first ?? saved)
    }

    var body: some View {
        let tabs = Self.tabs(model)
        let tab = current(in: tabs)
        VStack(alignment: .leading, spacing: 8) {
            header(tabs: placeholder && tabs.isEmpty ? [tab] : tabs, current: tab)
            if !folded {
                Group {
                    if placeholder {
                        ghostCards
                    } else {
                        cards(tab)
                            .id(tab)
                            .transition(.opacity)
                    }
                }
                .frame(height: Self.cardHeight)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8)
        .padding(.bottom, folded ? 4 : 12)
        .motion(Motion.rows, value: folded)
        .motion(Motion.fade, value: tab)
        .haptic(.selection, trigger: tabRaw)
        .haptic(.impact(weight: .light), trigger: folded)
        .onAppear { if !placeholder, !tabs.isEmpty { seen = true } }
        .accessibilityElement(children: .contain)
    }

    // MARK: header

    private func header(tabs: [Tab], current: Tab) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            ForEach(tabs) { tab in
                Button {
                    tabRaw = tab.rawValue
                    folded = false
                } label: {
                    tabLabel(tab, selected: tab == current)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == current ? [.isHeader, .isSelected] : [])
            }
            Spacer(minLength: 8)
            if !placeholder, current != .edits, !folded {
                Button(Copy.Library2.seeAllLinks) { model.selectedTab = .links }
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.linkBlue)
                    .buttonStyle(.plain)
            }
            Button {
                folded.toggle()
            } label: {
                Image(systemName: folded ? Symbol.Library.shelfUnfold : Symbol.Library.shelfFold)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CobaltColor.caption)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(folded ? Copy.Library2.shelfUnfold : Copy.Library2.shelfFold)
            .accessibilityLabel(folded ? Copy.Library2.shelfUnfold : Copy.Library2.shelfFold)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(minHeight: 32)
    }

    private func tabLabel(_ tab: Tab, selected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(word(tab))
                .font(selected ? CobaltType.bodySemibold : CobaltType.body)
                .foregroundStyle(selected ? CobaltColor.text : CobaltColor.caption)
            if !placeholder {
                Text("\(count(tab))")
                    .font(CobaltType.captionSmall)
                    .foregroundStyle(CobaltColor.caption)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }

    private func word(_ tab: Tab) -> String {
        switch tab {
        case .links: return Copy.Library2.shelfLinks
        case .edits: return Copy.Editor.edits
        case .collections: return Copy.Library2.collectionsShelf
        }
    }

    private func count(_ tab: Tab) -> Int {
        switch tab {
        case .links: return store.sets.count
        case .edits: return model.editor.projects.count
        case .collections: return store.collections.count
        }
    }

    // MARK: cards

    @ViewBuilder
    private func cards(_ tab: Tab) -> some View {
        switch tab {
        case .edits:
            LibraryEditsShelf(model: model)
        case .links:
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(store.sets.prefix(Self.cardLimit)) { link in
                        Button { copy(link) } label: { RecentLinkCard(link: link) }
                            .buttonStyle(.plain)
                            .accessibilityHint(Copy.Library2.copyLinkHint)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollClipDisabled()
        case .collections:
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(store.collections) { collection in
                        let links = store.sets(in: collection)
                        NavigationLink(value: CollectionRoute(id: collection.id)) {
                            CollectionCard(name: collection.name, links: links)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Copy.Library2.openCollectionHint)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollClipDisabled()
            .accessibilityLabel(Copy.Library2.collectionsShelf)
        }
    }

    /// Grey cards the shape of a link card, under one band of light.
    private var ghostCards: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Skeleton.fill)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(Skeleton.fill).frame(width: 96, height: 9)
                        Capsule().fill(Skeleton.fill).frame(width: 64, height: 7)
                        Capsule().fill(Skeleton.fill).frame(width: 44, height: 7)
                    }
                    .frame(width: 112, alignment: .leading)
                }
                .padding(8)
                .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .skeletonShimmer()
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityHidden(true)
    }

    private func copy(_ link: ShareSet) {
        Pasteboard.copy(link.url.absoluteString)
        shell.showStatus(Copy.Media.copied)
        controller.doneTick += 1
    }
}

/// A link on the shelf: its files as a 2x2 cover, the title, how many files and when, and `copy link`.
private struct RecentLinkCard: View {
    let link: ShareSet

    var body: some View {
        let files = Copy.Links.fileCount(link.items.count)
        let when = Format.when(link.createdAt, now: Date())
        // an untitled link is already called "10 files": its second line then says only when
        let detail = link.displayTitle == files ? when : "\(files) · \(when)"
        ShelfCard {
            LinkCover(items: link.items, side: 56)
        } lines: {
            Text(link.displayTitle)
                .font(CobaltType.bodyMedium)
                .foregroundStyle(CobaltColor.text)
                .lineLimit(1)
            Text(detail)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
                .lineLimit(1)
            Text(Copy.Links.copyLink)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.linkBlue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Links.rowA11y(title: link.displayTitle, files: link.items.count, when: when))
        .accessibilityAddTraits(.isButton)
    }
}

/// A collection on the shelf: the cover of its newest link's files, its name, how many links, and `open`.
private struct CollectionCard: View {
    let name: String
    let links: [ShareSet]

    var body: some View {
        ShelfCard {
            ZStack {
                LinkCover(items: Array(links.flatMap(\.items).prefix(4)), side: 56)
                if links.isEmpty {
                    Image(systemName: Symbol.collection)
                        .symbolVariant(.fill)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(CobaltColor.collection)
                }
            }
        } lines: {
            HStack(spacing: 4) {
                Image(systemName: Symbol.collection)
                    .symbolVariant(.fill)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CobaltColor.collection)
                Text(name)
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(1)
            }
            Text(Copy.Collections.linkCount(links.count))
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.caption)
            Text(Copy.Editor.open)
                .font(CobaltType.badge)
                .foregroundStyle(CobaltColor.linkBlue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Collections.rowA11y(name: name, links: links.count))
        .accessibilityAddTraits(.isButton)
    }
}

/// The shelf's one card shape: a 56 pt cover, three short lines, 72 pt tall in all.
struct ShelfCard<Cover: View, Lines: View>: View {
    @ViewBuilder let cover: Cover
    @ViewBuilder let lines: Lines

    var body: some View {
        HStack(spacing: 10) {
            cover
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) { lines }
                .frame(width: 118, alignment: .leading)
        }
        .padding(8)
        .frame(height: LibraryShelves.cardHeight)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
