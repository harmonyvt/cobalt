import CobaltKit
import SwiftUI

// The collections section of the links tab (APP-API-CONTRACT section 26): a "new collection" row and one row per
// collection. A collection row pushes `CollectionScreen`; its swipe and context menu rename and delete.

/// The push to a collection's screen (the id; the screen reads the live collection from the store).
struct CollectionRoute: Hashable {
    let id: String
}

/// `new collection`: a folder-with-plus tile and the label; a tap opens the sheet.
struct NewCollectionRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Symbol.collectionNew)
                .font(.system(size: 20))
                .foregroundStyle(CobaltColor.focus)
                .frame(width: 44, height: 44)
                .background(CobaltColor.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(Copy.Collections.new)
                .font(CobaltType.bodySemibold)
                .foregroundStyle(CobaltColor.focus)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .frame(minHeight: Metrics.hit)
        .contentShape(Rectangle())
    }
}

/// One collection: a folder symbol, its name, "N links" and a small thumbnail of its first link.
struct CollectionRow: View {
    let collection: ShareCollection
    let store: ShareSetStore
    let controller: LinksController

    var body: some View {
        let links = store.sets(in: collection)
        NavigationLink(value: CollectionRoute(id: collection.id)) {
            HStack(spacing: 12) {
                Image(systemName: Symbol.collection)
                    .font(.system(size: 18))
                    .foregroundStyle(CobaltColor.caption)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.name)
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.text)
                        .lineLimit(1)
                    Text(Copy.Collections.linkCount(collection.setIDs.count))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                }
                Spacer(minLength: 4)
                if let first = links.first, let item = first.items.first(where: \.isPublic) ?? first.items.first {
                    LinkThumb(item: item, side: 40)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 2)
            .frame(minHeight: Metrics.hit)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Copy.Collections.rowA11y(name: collection.name, links: collection.setIDs.count))
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(Copy.Collections.delete, systemImage: Symbol.collectionDelete, role: .destructive) {
                controller.deleting = collection
            }
            Button(Copy.Collections.rename, systemImage: Symbol.collectionRename) {
                controller.sheet = .rename(collection)
            }
            .tint(CobaltColor.focus)
        }
        #endif
        .contextMenu {
            Button(Copy.Collections.rename, systemImage: Symbol.collectionRename) { controller.sheet = .rename(collection) }
            Divider()
            Button(Copy.Collections.delete, systemImage: Symbol.collectionDelete, role: .destructive) {
                controller.deleting = collection
            }
        }
    }
}
