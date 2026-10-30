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
            ForEach(controller.shownCollections) { collection in
                Button { open(collection) } label: {
                    CollectionFolderCard(collection: collection, links: store.sets(in: collection))
                }
                .buttonStyle(.borderless)
                .contextMenu { CollectionMenuItems(collection: collection, controller: controller) }
            }
            // inside a set, the dashed card would make a collection outside it: the menu's `sets` adds one instead
            if controller.selectedSet == nil {
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
        }
        .motion(Motion.rows, value: controller.shownCollections.map(\.id))
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
        if controller.privateLinksEnabled {
            CollectionPrivacyMenu(collection: collection, controller: controller)
        }
        if controller.setsEnabled {
            // which sets hold it: a tick on each, a tap moves it in or out
            Menu(Copy.Sets.sets, systemImage: Symbol.collectionSet) {
                ForEach(controller.store.groups) { set in
                    Toggle(set.name, isOn: Binding(
                        get: { set.contains(collection.id) },
                        set: { _ in controller.toggle(collection, in: set, shell: shell) }))
                }
                if !controller.store.groups.isEmpty { Divider() }
                Button(Copy.Sets.newWith(collection.name), systemImage: Symbol.collectionSetNew) {
                    controller.naming = .create(including: collection.id)
                }
            }
        }
        Divider()
        Button(Copy.Collections.delete, systemImage: Symbol.collectionDelete, role: .destructive) {
            controller.deleting = collection
        }
    }
}

/// A collection's `privacy…` (APP-API-CONTRACT 36.6): make every link private (at once), rotate every key and make every
/// link public (both ask first). In the folder card's long press, the collection screen's menu and on the Mac.
struct CollectionPrivacyMenu: View {
    let collection: ShareCollection
    let controller: LinksController
    @Environment(\.shell) private var shell

    var body: some View {
        let store = controller.store
        let privateCount = store.privateCount(in: collection)
        let total = store.sets(in: collection).count
        Menu {
            if total > 0 {
                Text(Copy.PrivateLinks.privateOf(privateCount, total))
            }
            Button(Copy.PrivateLinks.everyPrivate, systemImage: Symbol.PrivateLinks.makePrivate) {
                controller.choosePrivacy(.makePrivate, for: collection, shell: shell)
            }
            .disabled(privateCount == total)
            Button(Copy.PrivateLinks.everyRotate, systemImage: Symbol.PrivateLinks.rotate) {
                controller.choosePrivacy(.rotate, for: collection, shell: shell)
            }
            .disabled(privateCount == 0)
            Button(Copy.PrivateLinks.everyPublic, systemImage: Symbol.PrivateLinks.makePublic, role: .destructive) {
                controller.choosePrivacy(.makePublic, for: collection, shell: shell)
            }
            .disabled(privateCount == 0)
        } label: {
            Label(Copy.PrivateLinks.privacy, systemImage: Symbol.PrivateLinks.privacy)
        }
        .disabled(!controller.canChangePrivacy(collection))
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

/// The sets over the collection folders (APP-API-CONTRACT section 28): `all`, then a chip per set (how many collections
/// it holds), then `new set`. A chip on shows only that set's collections, with its bar (copy all links, rename,
/// delete) under the chips. A chip's long press offers the same.
struct CollectionSetChips: View {
    let store: ShareSetStore
    @Bindable var controller: LinksController
    @Environment(\.shell) private var shell

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(title: Copy.Sets.chip(Copy.Sets.all, count: store.collections.count), symbol: nil, on: controller.selectedSet == nil) {
                        controller.selectedSetID = nil
                    }
                    ForEach(store.groups) { set in
                        chip(title: Copy.Sets.chip(set.name, count: store.collections(in: set).count), symbol: Symbol.collectionSet,
                             on: controller.selectedSetID == set.id) {
                            controller.selectedSetID = controller.selectedSetID == set.id ? nil : set.id
                        }
                        .contextMenu { items(set) }
                        .id(set.id)
                    }
                    Button { controller.naming = .create(including: nil) } label: {
                        Label(Copy.Sets.new, systemImage: Symbol.collectionSetNew)
                            .font(Font.cobalt(11.5, .regular, relativeTo: .caption))
                            .foregroundStyle(CobaltColor.caption)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .overlay(Capsule().strokeBorder(CobaltColor.border, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .onChange(of: controller.selectedSetID) { _, id in
                guard let id else { return }
                withAnimation(Motion.rows) { proxy.scrollTo(id, anchor: .center) }
            }
            }
            if let set = controller.selectedSet {
                HStack(spacing: 8) {
                    Text(Copy.Sets.collectionCount(store.collections(in: set).count))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.collectionSet)
                    Spacer(minLength: 8)
                    Button(Copy.Sets.copyAll, systemImage: Symbol.collectionCopyAll) { controller.copyAll(set, shell: shell) }
                        .buttonStyle(.cobaltSecondary(fullWidth: false, compact: true))
                        .disabled(store.linksText(in: set) == nil)
                    Menu {
                        items(set)
                    } label: {
                        Image(systemName: Symbol.collectionMenu)
                            .font(.system(size: 18))
                            .foregroundStyle(CobaltColor.collectionSet)
                            .frame(width: 34, height: 34)
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(CobaltColor.collectionSetBack, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if store.collections(in: set).isEmpty {
                    Text(Copy.Sets.emptySet)
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                }
            }
        }
        .motion(Motion.rows, value: controller.selectedSetID)
        .motion(Motion.rows, value: store.groups.map(\.id))
    }

    @ViewBuilder
    private func items(_ set: CollectionGroup) -> some View {
        Button(Copy.Sets.copyAll, systemImage: Symbol.collectionCopyAll) { controller.copyAll(set, shell: shell) }
            .disabled(store.linksText(in: set) == nil)
        Button(Copy.Sets.rename, systemImage: Symbol.collectionRename) { controller.naming = .rename(set) }
        Divider()
        Button(Copy.Sets.delete, systemImage: Symbol.collectionDelete, role: .destructive) { controller.deletingSet = set }
    }

    private func chip(title: String, symbol: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                }
                Text(title)
                    .font(Font.cobalt(11.5, on ? .semibold : .regular, relativeTo: .caption))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(on ? CobaltColor.onText : (symbol == nil ? Color.primary : CobaltColor.collectionSet))
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(Capsule().fill(on ? (symbol == nil ? CobaltColor.text : CobaltColor.collectionSet) : CobaltColor.elevated))
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
