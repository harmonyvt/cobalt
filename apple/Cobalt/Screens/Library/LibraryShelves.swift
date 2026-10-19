import CobaltKit
import SwiftUI

/// What the iPhone's mosaic shows above the tiles while the server makes gallery share links: the owner's newest links
/// as a row of cards (a tap copies the link; `see all` opens the links tab) and their collections as amber chips (a tap
/// opens the collection). It scrolls with the tiles. Hidden while selecting or searching, and when there is nothing in
/// it. The tiles below carry the same story per post (`SharedTileBadges`).
struct LibraryShelves: View {
    let model: AppModel
    let controller: LibraryController

    @Environment(\.shell) private var shell

    private var store: ShareSetStore { model.shareSets }

    /// The cards: the newest links (the links tab has the rest).
    static let cardLimit = 12

    /// Whether the shelves have anything to show for this model.
    static func hasContent(_ model: AppModel) -> Bool {
        guard model.capabilities.shareSets else { return false }
        return !model.shareSets.sets.isEmpty || showsCollections(model)
    }

    private static func showsCollections(_ model: AppModel) -> Bool {
        model.capabilities.shareCollections && !model.shareSets.collections.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.sets.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Copy.Library2.recentLinks)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                    Text("\(store.sets.count)")
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                    Spacer(minLength: 8)
                    Button(Copy.Library2.seeAllLinks) { model.selectedTab = .links }
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.linkBlue)
                        .buttonStyle(.plain)
                        .frame(minHeight: 32)
                }
                .padding(.horizontal, 16)
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
            }
            if Self.showsCollections(model) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.collections) { collection in
                            NavigationLink(value: CollectionRoute(id: collection.id)) {
                                CollectionChip(name: collection.name, links: store.sets(in: collection).count)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Copy.Library2.openCollectionHint)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .accessibilityLabel(Copy.Library2.collectionsShelf)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func copy(_ link: ShareSet) {
        Pasteboard.copy(link.url.absoluteString)
        shell.showStatus(Copy.Media.copied)
        controller.doneTick += 1
    }
}

/// A link on the library's shelf: its files as a 2x2 cover, the title, and how many files and when.
private struct RecentLinkCard: View {
    let link: ShareSet

    var body: some View {
        HStack(spacing: 10) {
            LinkCover(items: link.items, side: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(link.displayTitle)
                    .font(CobaltType.bodyMedium)
                    .foregroundStyle(CobaltColor.text)
                    .lineLimit(2)
                Text("\(Copy.Links.fileCount(link.items.count)) · \(Format.when(link.createdAt, now: Date()))")
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.caption)
                    .lineLimit(1)
                Text(Copy.Links.copyLink)
                    .font(CobaltType.badge)
                    .foregroundStyle(CobaltColor.linkBlue)
            }
            .frame(width: 112, alignment: .leading)
        }
        .padding(8)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Copy.Links.rowA11y(
                title: link.displayTitle, files: link.items.count, when: Format.when(link.createdAt, now: Date())))
        .accessibilityAddTraits(.isButton)
    }
}

/// A collection as an amber chip: the folder, its name and how many links it holds.
struct CollectionChip: View {
    let name: String
    let links: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Symbol.collection)
                .symbolVariant(.fill)
                .font(.system(size: 12, weight: .semibold))
            Text(name)
                .font(CobaltType.bodyMedium)
                .lineLimit(1)
            // "2 links", so it does not read as the share chips' post counts
            Text(Copy.Collections.linkCount(links))
                .font(CobaltType.captionSmall)
                .opacity(0.7)
        }
        .foregroundStyle(CobaltColor.collection)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(CobaltColor.collectionBack, in: Capsule())
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Collections.rowA11y(name: name, links: links))
        .accessibilityAddTraits(.isButton)
    }
}
