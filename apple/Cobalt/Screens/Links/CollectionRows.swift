import CobaltKit
import SwiftUI

// The collections section of the links tab (APP-API-CONTRACT section 26): a grid of folder cards and a "new collection"
// card. A card opens `CollectionScreen`; its long press copies all, renames, rerolls and deletes.

/// The push to a collection's screen (the id; the screen reads the live collection from the store).
struct CollectionRoute: Hashable {
    let id: String
}

/// The collections as Glassy Adaptive Bento folders: two to a row (even counts on wide/Duo windows), each with an
/// adaptive 16:10 media cover of its newest links, amber title, link count, and a 1-tap copy-all button. A tap opens
/// the collection; the long press copies all, renames, rerolls, sets privacy, assigns sets, and deletes.
struct CollectionFolderGrid: View {
    let store: ShareSetStore
    let controller: LinksController
    let open: (ShareCollection) -> Void

    @Environment(\.shell) private var shell

    var body: some View {
        let shown = controller.shownCollections
        let copiedCollectionID = controller.copiedCollectionID
        if shown.isEmpty, controller.selectedSet == nil {
            Button { controller.newCollection(including: nil) } label: {
                HStack(spacing: 8) {
                    Image(systemName: Symbol.collectionNew)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CobaltColor.collection)
                    Text(Copy.Collections.new)
                        .font(CobaltType.bodyMedium)
                        .foregroundStyle(CobaltColor.text)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(CobaltColor.collection.opacity(0.10)).interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(CobaltColor.collection.opacity(0.32), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .allowsHitTesting(false)
            )
        } else {
            DuoAdaptiveGrid(minItemWidth: 156, spacing: 10) {
                ForEach(shown) { collection in
                    let links = store.sets(in: collection)
                    let privateCount = controller.privateLinksEnabled ? store.privateCount(in: collection) : 0
                    let canCopy = store.linksText(in: collection) != nil
                    CollectionFolderCard(
                        collection: collection,
                        links: links,
                        privateCount: privateCount,
                        canCopy: canCopy,
                        copied: copiedCollectionID == collection.id,
                        onOpen: { open(collection) },
                        onCopyAll: { controller.copyAll(collection, shell: shell) }
                    )
                    .contextMenu { CollectionMenuItems(collection: collection, controller: controller) }
                }
            }
            .motion(Motion.rows, value: shown.map(\.id))
        }
    }
}

/// One Glassy Adaptive Bento folder card: adaptive 16:10 cover on top (zero empty boxes), optional Clear Liquid Glass
/// privacy pill, amber folder title, link count, and a 1-tap copy-all button with green checkmark feedback.
struct CollectionFolderCard: View {
    let collection: ShareCollection
    let links: [ShareSet]
    var privateCount: Int = 0
    var canCopy: Bool = false
    var copied: Bool = false
    var onOpen: (() -> Void)? = nil
    var onCopyAll: (() -> Void)? = nil

    /// A file per link, the public one first, newest links first.
    private var coverItems: [ShareSetItem] {
        links.prefix(4).compactMap { $0.items.first(where: \.isPublic) ?? $0.items.first }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                BentoMediaCover(items: coverItems, totalCount: links.count, cornerRadius: 12)
                if privateCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: Symbol.PrivateLinks.lock)
                            .font(.system(size: 9, weight: .bold))
                        if privateCount < links.count {
                            Text("\(privateCount)")
                                .font(Font.cobalt(9.5, .semibold, relativeTo: .caption2))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .mediaGlassCapsule(interactive: false)
                    .padding(6)
                }
            }
            .padding([.top, .horizontal], 6)

            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(collection.name, systemImage: Symbol.collection)
                        .labelStyle(CollectionLineLabel())
                        .font(CobaltType.bodySemibold)
                        .foregroundStyle(CobaltColor.collection)
                        .lineLimit(1)
                    Text(Copy.Collections.linkCount(collection.setIDs.count))
                        .font(CobaltType.captionSmall)
                        .foregroundStyle(CobaltColor.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Copy.Collections.rowA11y(name: collection.name, links: collection.setIDs.count))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onOpen?() }

                if let onCopyAll, canCopy {
                    Button(action: onCopyAll) {
                        Image(systemName: copied ? Symbol.Library.copied : Symbol.copyLink)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(copied ? .white : CobaltColor.text)
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        .regular.tint(copied ? CobaltColor.success : CobaltColor.elevated.opacity(0.6)).interactive(),
                        in: .circle
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(copied ? CobaltColor.success.opacity(0.5) : CobaltColor.hairline, lineWidth: 0.6)
                            .allowsHitTesting(false)
                    )
                    .accessibilityLabel(Copy.Collections.copyAll)
                    .animation(Motion.chip, value: copied)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassEffect(.regular.tint(CobaltColor.surface.opacity(0.55)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CobaltColor.hairline, lineWidth: 0.7)
                .allowsHitTesting(false)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { onOpen?() }
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
        if controller.setsEnabled { CollectionSetsMenu(collection: collection, controller: controller) }
        Divider()
        Button(Copy.Collections.delete, systemImage: Symbol.collectionDelete, role: .destructive) {
            controller.deleting = collection
        }
    }
}

/// Which sets hold a collection: a tick on each, a tap moves it in or out, then "new set with …". The long press's `sets`
/// and the collection page's own menu.
struct CollectionSetsMenu: View {
    let collection: ShareCollection
    let controller: LinksController
    @Environment(\.shell) private var shell

    var body: some View {
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
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            chip(
                                title: Copy.Sets.chip(Copy.Sets.all, count: store.collections.count),
                                symbol: nil,
                                on: controller.selectedSet == nil
                            ) {
                                controller.selectedSetID = nil
                            }
                            ForEach(store.groups) { set in
                                chip(
                                    title: Copy.Sets.chip(set.name, count: store.collections(in: set).count),
                                    symbol: Symbol.collectionSet,
                                    on: controller.selectedSetID == set.id
                                ) {
                                    controller.selectedSetID = controller.selectedSetID == set.id ? nil : set.id
                                }
                                .contextMenu { items(set) }
                                .id(set.id)
                            }
                            Button { controller.naming = .create(including: nil) } label: {
                                Label(Copy.Sets.new, systemImage: Symbol.collectionSetNew)
                                    .font(Font.cobalt(11.5, .medium, relativeTo: .caption))
                                    .foregroundStyle(CobaltColor.caption)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 32)
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(CobaltColor.border, style: StrokeStyle(lineWidth: 1.1, dash: [4, 3]))
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .scrollClipDisabled()
                .onChange(of: controller.selectedSetID) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.rows) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if let set = controller.selectedSet {
                HStack(spacing: 8) {
                    Label(Copy.Sets.collectionCount(store.collections(in: set).count), systemImage: Symbol.collectionSet)
                        .labelStyle(CollectionLineLabel())
                        .font(CobaltType.captionSmall.weight(.semibold))
                        .foregroundStyle(CobaltColor.collectionSet)
                    Spacer(minLength: 8)
                    Button { controller.copyAll(set, shell: shell) } label: {
                        Label(Copy.Sets.copyAll, systemImage: Symbol.collectionCopyAll)
                    }
                    .buttonStyle(.cobaltIcon(.small, tint: CobaltColor.collectionSet))
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
                    .iconName(Copy.Sets.menu)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(
                    .regular.tint(CobaltColor.collectionSet.opacity(0.14)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(CobaltColor.collectionSet.opacity(0.3), lineWidth: 0.65)
                        .allowsHitTesting(false)
                )
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
        let isSet = symbol != nil
        let glassTint: Color = on
            ? (isSet ? CobaltColor.collectionSet : CobaltColor.text)
            : (isSet ? CobaltColor.collectionSet.opacity(0.14) : CobaltColor.elevated.opacity(0.55))
        return Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                }
                Text(title)
                    .font(Font.cobalt(11.5, on ? .semibold : .medium, relativeTo: .caption))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(on ? CobaltColor.onText : (isSet ? CobaltColor.collectionSet : CobaltColor.text))
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(glassTint).interactive(), in: .capsule)
        .overlay(
            Capsule()
                .strokeBorder(
                    on ? Color.clear : (isSet ? CobaltColor.collectionSet.opacity(0.32) : CobaltColor.hairline),
                    lineWidth: 0.65
                )
                .allowsHitTesting(false)
        )
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
