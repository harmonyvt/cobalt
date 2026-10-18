import CobaltKit
import SwiftUI

// The collections section of the links tab (APP-API-CONTRACT section 26): a grid of folder cards and a "new collection"
// card. A card opens `CollectionScreen`; its long press copies all, renames, rerolls and deletes.

/// The push to a collection's screen (the id; the screen reads the live collection from the store).
struct CollectionRoute: Hashable {
    let id: String
}

/// The collections as folders (links tab, design A): two to a row (three or more on a wide window), each with a 2x2
/// cover of its newest links, its name and how many links; then a dashed "new collection" card. A tap opens the
/// collection; the long press copies all, renames, rerolls and deletes (`CollectionMenuItems`).
struct CollectionFolderGrid: View {
    let store: ShareSetStore
    let controller: LinksController
    let open: (ShareCollection) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(store.collections) { collection in
                Button { open(collection) } label: {
                    CollectionFolderCard(collection: collection, links: store.sets(in: collection))
                }
                .buttonStyle(.borderless)
                .contextMenu { CollectionMenuItems(collection: collection, controller: controller) }
            }
            Button { controller.newCollection(including: nil) } label: {
                VStack(spacing: 6) {
                    Image(systemName: Symbol.collectionNew)
                        .font(.system(size: 20))
                    Text(Copy.Collections.new)
                        .font(CobaltType.bodyMedium)
                }
                .foregroundStyle(CobaltColor.caption)
                .frame(maxWidth: .infinity, minHeight: CollectionFolderCard.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(CobaltColor.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.borderless)
        }
        .motion(Motion.rows, value: store.collections.map(\.id))
    }
}

/// One folder: the cover (one file from each of the newest four links), the name in the collection amber, the count.
struct CollectionFolderCard: View {
    let collection: ShareCollection
    let links: [ShareSet]

    static let height: CGFloat = 132

    /// A file per link, the public one first, newest links first.
    private var coverItems: [ShareSetItem] {
        links.prefix(4).compactMap { $0.items.first(where: \.isPublic) ?? $0.items.first }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LinkCover(items: coverItems, side: 64)
            Label(collection.name, systemImage: Symbol.collection)
                .labelStyle(CollectionLineLabel())
                .font(CobaltType.bodySemibold)
                .foregroundStyle(CobaltColor.collection)
                .lineLimit(1)
            Text(Copy.Collections.linkCount(collection.setIDs.count))
                .font(CobaltType.captionSmall)
                .foregroundStyle(CobaltColor.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .topLeading)
        .background(CobaltColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Collections.rowA11y(name: collection.name, links: collection.setIDs.count))
        .accessibilityAddTraits(.isButton)
    }
}

/// A collection's long-press items, shared by its row and its folder card.
struct CollectionMenuItems: View {
    let collection: ShareCollection
    let controller: LinksController
    @Environment(\.shell) private var shell

    var body: some View {
        Button(Copy.Collections.copyAll, systemImage: Symbol.collectionCopyAll) { controller.copyAll(collection, shell: shell) }
            .disabled(controller.store.linksText(in: collection) == nil)
        Button(Copy.Collections.rename, systemImage: Symbol.collectionRename) { controller.sheet = .rename(collection) }
        Button(Copy.Collections.reroll, systemImage: Symbol.collectionReroll) { controller.rerolling = collection }
            .disabled(!controller.canReroll(collection))
        Divider()
        Button(Copy.Collections.delete, systemImage: Symbol.collectionDelete, role: .destructive) {
            controller.deleting = collection
        }
    }
}

/// A small filled folder before the text, tight: the collection lines and folder names.
struct CollectionLineLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .symbolVariant(.fill)
                .imageScale(.small)
            configuration.title
        }
    }
}
